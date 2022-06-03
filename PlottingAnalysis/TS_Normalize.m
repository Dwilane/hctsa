function outputFileName = TS_Normalize(normFunction,filterOptions,fileName_HCTSA,classVarFilter,keepCalcTime)
% TS_Normalize  Trims and normalizes data from an hctsa analysis.
%
% Reads in data from HCTSA.mat, writes a trimmed, normalized version to HCTSA_N.mat
% For many normalization settings, each feature is normalized to the unit interval
% for the purposes of visualization and clustering.
%
%---INPUTS:
% normFunction: String specifying how to normalize the data.
%
% filterOptions: Vector specifying thresholds for the minimum proportion of good
%                values required in a given row or column, in the form of a 2-vector:
%                [row proportion, column proportion]. If one of the filterOptions
%                is set to 1, will have no bad values in your matrix.
%
% fileName_HCTSA: Custom hctsa data to import. Default: loaded from 'HCTSA.mat'.
%
% classVarFilter: whether to filter on zero variance of any given class (which
%                 can cause problems for many classification algorithms).
%
% keepCalcTime: whether to keep TS_CalcTime

% ------------------------------------------------------------------------------
% Copyright (C) 2020, Ben D. Fulcher <ben.d.fulcher@gmail.com>,
% <http://www.benfulcher.com>
%
% If you use this code for your research, please cite the following two papers:
%
% (1) B.D. Fulcher and N.S. Jones, "hctsa: A Computational Framework for Automated
% Time-Series Phenotyping Using Massive Feature Extraction, Cell Systems 5: 527 (2017).
% DOI: 10.1016/j.cels.2017.10.001
%
% (2) B.D. Fulcher, M.A. Little, N.S. Jones, "Highly comparative time-series
% analysis: the empirical structure of time series and their methods",
% J. Roy. Soc. Interface 10(83) 20130048 (2013).
% DOI: 10.1098/rsif.2013.0048
%
% This work is licensed under the Creative Commons
% Attribution-NonCommercial-ShareAlike 4.0 International License. To view a copy of
% this license, visit http://creativecommons.org/licenses/by-nc-sa/4.0/ or send
% a letter to Creative Commons, 444 Castro Street, Suite 900, Mountain View,
% California, 94041, USA.
% ------------------------------------------------------------------------------

% --------------------------------------------------------------------------
%% Check Inputs
% --------------------------------------------------------------------------
if nargin < 1 || isempty(normFunction)
    fprintf(1,'Using the mixed sigmoidal transform: ''mixedSigmoid''\n')
    normFunction = 'mixedSigmoid';
end

if nargin < 2 || isempty(filterOptions)
    filterOptions = [0.70,1];
    % By default remove less than 70%-good-valued time series, & then less than
    % 100%-good-valued operations.
end
if any(filterOptions > 1)
    error('Set filterOptions as a length-2 vector with elements in the unit interval');
end
fprintf(1,['Removing time series with more than %.2f%% special-valued outputs\n' ...
            'Removing operations with more than %.2f%% special-valued outputs\n'], ...
            (1-filterOptions(1))*100,(1-filterOptions(2))*100);

% By default, work HCTSA.mat, e.g., generated by SQL_Retrieve or TS_Init
if nargin < 3 || isempty(fileName_HCTSA)
    fileName_HCTSA = 'HCTSA.mat';
end

if nargin < 4
    classVarFilter = false; % don't filter on individual class variance > 0 by default
end

if nargin < 5
    % Save space in normalized dataset
    keepCalcTime = false;
end

% --------------------------------------------------------------------------
%% Read data from local files
% --------------------------------------------------------------------------

% Load data:
[TS_DataMat,TimeSeries,Operations,whatDataFile] = TS_LoadData(fileName_HCTSA);
TS_Quality = TS_GetFromData(fileName_HCTSA,'TS_Quality');
MasterOperations = TS_GetFromData(fileName_HCTSA,'MasterOperations');

if keepCalcTime
    TS_CalcTime = TS_GetFromData(fileName_HCTSA,'TS_Quality');
end

% Check that fromDatabase exists (legacy)
fromDatabase = TS_GetFromData(fileName_HCTSA,'fromDatabase');
if isempty(fromDatabase)
    fromDatabase = true; % (legacy)
end

% Maybe we kept the git repository info
gitInfo = TS_GetFromData(fileName_HCTSA,'gitInfo');

%-------------------------------------------------------------------------------
% In this script, each of these pieces of data (from the database) will be
% trimmed and normalized, and then saved to HCTSA_N.mat
%-------------------------------------------------------------------------------

% --------------------------------------------------------------------------
%% Trim down bad rows/columns
% --------------------------------------------------------------------------

% (i) NaNs in TS_DataMat mean values uncalculated in the matrix.
TS_DataMat(~isfinite(TS_DataMat)) = NaN; % Convert all nonfinite values to NaNs for consistency
% Need to also incorporate knowledge of bad entries in TS_Quality and filter these out:
TS_DataMat(TS_Quality > 0) = NaN;
numSpecialValues = sum(TS_Quality(:) > 0);
fprintf(1,'\nThere are %u special values in the data matrix.\n',numSpecialValues);
percGoodRows = mean(~isnan(TS_DataMat),2)*100;
percGoodCols = mean(~isnan(TS_DataMat),1)*100;
fprintf(1,'(pre-filtering): Time series vary from %.2f--%.2f%% good values\n',...
                min(percGoodRows),max(percGoodRows));
fprintf(1,'(pre-filtering): Features vary from %.2f--%.2f%% good values\n',...
                min(percGoodCols),max(percGoodCols));

% Now that all bad values are NaNs, and we can get on with the job of filtering them out

% (*) Filter based on proportion of bad entries. If either threshold is 1,
% the resulting matrix is guaranteed to be free from bad values entirely.

% Filter time series (rows)
keepRows = filterNaNs(TS_DataMat,filterOptions(1),'time series');
if any(~keepRows)
    fprintf(1,'Time series removed: %s.\n\n',BF_cat(TimeSeries.Name(~keepRows),','));
    TS_DataMat = TS_DataMat(keepRows,:);
    TS_Quality = TS_Quality(keepRows,:);
    TimeSeries = TimeSeries(keepRows,:);
    if keepCalcTime
        TS_CalcTime = TS_CalcTime(keepRows,:);
    end
end

% Filter operations (columns)
keepCols = filterNaNs(TS_DataMat',filterOptions(2),'operations');
if any(~keepCols)
    TS_DataMat = TS_DataMat(:,keepCols);
    TS_Quality = TS_Quality(:,keepCols);
    Operations = Operations(keepCols,:);
    if keepCalcTime
        TS_CalcTime = TS_CalcTime(:,keepCols);
    end
end

% --------------------------------------------------------------------------
%% Filter out operations that are constant across the time-series dataset
%% And time series with constant feature vectors
% --------------------------------------------------------------------------
if size(TS_DataMat,1) > 1 % otherwise just a single time series remains and all will be constant!
    bad_op = (nanstd(TS_DataMat) < 10*eps);

    if all(bad_op)
        error('All %u operations produced constant outputs on the %u time series?!',...
                            length(bad_op),size(TS_DataMat,1))
    elseif any(bad_op)
        fprintf(1,'Removed %u operations with near-constant outputs: from %u to %u.\n',...
                         sum(bad_op),length(bad_op),sum(~bad_op));
        TS_DataMat = TS_DataMat(:,~bad_op);
        TS_Quality = TS_Quality(:,~bad_op);
        Operations = Operations(~bad_op,:);
        if keepCalcTime
            TS_CalcTime = TS_CalcTime(:,~bad_op);
        end
    else
        fprintf(1,'No operations had near-constant outputs on the dataset\n');
    end
end

%-------------------------------------------------------------------------------
% Filter on class variance
%-------------------------------------------------------------------------------
if classVarFilter
    if ~ismember('Group',TimeSeries.Properties.VariableNames)
        fprintf(1,'Group labels not assigned to time series, so cannot filter on class variance\n');
    end
    classNames = categories(TimeSeries.Group);
    numClasses = length(classNames);
    classVars = zeros(numClasses,size(TS_DataMat,2));
    for i = 1:numClasses
        classVars(i,:) = nanstd(TS_DataMat(TimeSeries.Group==classNames{i},:));
    end
    zeroClassVar = any(classVars < 10*eps,1);
    if all(zeroClassVar)
        error('All %u operations produced near-constant class-wise outputs?!',...
                            length(zeroClassVar),size(TS_DataMat,1))
    elseif any(zeroClassVar)
        fprintf(1,'Removed %u operations with near-constant class-wise outputs: from %u to %u.\n',...
                     sum(zeroClassVar),length(zeroClassVar),sum(~zeroClassVar));
        TS_DataMat = TS_DataMat(:,~zeroClassVar);
        TS_Quality = TS_Quality(:,~zeroClassVar);
        Operations = Operations(~zeroClassVar,:);
        if keepCalcTime
            TS_CalcTime = TS_CalcTime(:,~zeroClassVar);
        end
    end
end

%-------------------------------------------------------------------------------
%% Update the labels after filtering
%-------------------------------------------------------------------------------
% At this point, you could check to see if any master operations are no longer
% pointed to and recalibrate the indexing, but I'm not going to bother.

if height(TimeSeries)==1
    % When there is only a single time series, it doesn't actually make sense to normalize
    error('Only a single time series remains in the dataset -- normalization cannot be applied');
end

numBadEntries = sum(isnan(TS_DataMat(:)));
percBadEntries = numBadEntries/length(TS_DataMat(:))*100;
if numBadEntries==0
    fprintf(1,'\n(post-filtering): No special-valued entries in the %ux%u data matrix!\n', ...
                size(TS_DataMat,1),size(TS_DataMat,2));
else
    fprintf(1,'\n(post-filtering): %u special-valued entries (%4.2f%%) remain in the %ux%u data matrix.\n',...
                numBadEntries,percBadEntries,size(TS_DataMat,1),size(TS_DataMat,2));

    percGoodCols = mean(~isnan(TS_DataMat),1)*100;
    percGoodRows = mean(~isnan(TS_DataMat),2)*100;
    fprintf(1,'(post-filtering): Time series vary from %.2f--%.2f%% good values.\n',...
                                min(percGoodRows),max(percGoodRows));
    fprintf(1,'(post-filtering): Features vary from %.2f--%.2f%% good values.\n',...
                                min(percGoodCols),max(percGoodCols));
end
fprintf(1,'\n');

% --------------------------------------------------------------------------
%% Filtering done, now apply the normalizing transformation
% --------------------------------------------------------------------------

if ismember(normFunction,{'nothing','none'})
    fprintf(1,'You specified ''%s'', so NO NORMALIZING IS ACTUALLY BEING DONE!!!\n',normFunction);
else
    fprintf(1,'Normalizing a %u x %u object. Please be patient...\n',...
                            height(TimeSeries),height(Operations));
    TS_DataMat = BF_NormalizeMatrix(TS_DataMat,normFunction);
    fprintf(1,'Normalized! The data matrix contains %u special-valued elements.\n',sum(isnan(TS_DataMat(:))));
end

% --------------------------------------------------------------------------
%% Remove bad entries
% --------------------------------------------------------------------------
% Bad entries after normalizing can be due to feature vectors that are
% constant after e.g., the sigmoid transform -- a bit of a weird thing to do if
% pre-filtering by percentage...

nanCol = (mean(isnan(TS_DataMat))==1);
if all(nanCol) % all columns are NaNs
    error('After normalization, all columns were bad-values... :(');
elseif any(nanCol) % there are columns that are all NaNs
    TS_DataMat = TS_DataMat(:,~nanCol);
    TS_Quality = TS_Quality(:,~nanCol);
    Operations = Operations(~nanCol,:);
    if keepCalcTime
        TS_CalcTime = TS_CalcTime(:,~nanCol);
    end
    fprintf(1,'We just removed %u all-NaN columns introduced from %s normalization.\n',...
                        sum(nanCol),normFunction);
end

% --------------------------------------------------------------------------
%% Make sure the operations are still good
% --------------------------------------------------------------------------
% Check again for ~constant columns after normalization
kc = (nanstd(TS_DataMat) < 10*eps);
if any(kc)
    TS_DataMat = TS_DataMat(:,~kc);
    TS_Quality = TS_Quality(:,~kc);
    Operations = Operations(~kc,:);
    if keepCalcTime
        TS_CalcTime = TS_CalcTime(:,~kc);
    end
    fprintf(1,'%u operations had near-constant outputs after filtering: from %u to %u.\n', ...
                    sum(kc),length(kc),sum(~kc));
end

numBadEntries = sum(isnan(TS_DataMat(:)));
percBadEntries = numBadEntries/length(TS_DataMat(:))*100;
if numBadEntries==0
    fprintf(1,'No special-valued entries in the %ux%u data matrix!\n', ...
                size(TS_DataMat,1),size(TS_DataMat,2));
else
    fprintf(1,'%u special-valued entries (%4.2f%%) in the %ux%u data matrix.\n', ...
                numBadEntries,percBadEntries,size(TS_DataMat,1),size(TS_DataMat,2));
end

% ------------------------------------------------------------------------------
% Set default clustering details
% ------------------------------------------------------------------------------
ts_clust = struct('distanceMetric','none','Dij',[],...
                'ord',1:size(TS_DataMat,1),'linkageMethod','none');
op_clust = struct('distanceMetric','none','Dij',[],...
                'ord',1:size(TS_DataMat,2),'linkageMethod','none');

% --------------------------------------------------------------------------
%% Save results to file
% --------------------------------------------------------------------------
% Make a structure with statistics on normalization:
% Save the codeToRun, so you can check the settings used to run the normalization
% At the moment, only saves the first two arguments
codeToRun = sprintf('TS_Normalize(''%s'',[%f,%f])',normFunction, ...
                                        filterOptions(1),filterOptions(2));
normalizationInfo = struct('normFunction',normFunction,'filterOptions', ...
                                    filterOptions,'codeToRun',codeToRun);

outputFileName = [fileName_HCTSA(1:end-4),'_N.mat'];

fprintf(1,'Saving the trimmed, normalized data to %s...',outputFileName);
if keepCalcTime
    save(outputFileName,'TS_DataMat','TS_Quality','TS_CalcTime','TimeSeries',...
            'Operations','MasterOperations','fromDatabase','normalizationInfo',...
            'gitInfo','ts_clust','op_clust','-v7.3');
else
    save(outputFileName,'TS_DataMat','TS_Quality','TimeSeries',...
            'Operations','MasterOperations','fromDatabase','normalizationInfo',...
            'gitInfo','ts_clust','op_clust','-v7.3');
end
fprintf(1,' Done.\n');

% Check whether output to screen is required:
if nargout == 0
    clear('outputFileName');
end

%-------------------------------------------------------------------------------
function keepInd = filterNaNs(XMat,nan_thresh,objectName)
    % Returns an index of rows of XMat with at least nan_thresh good values.

    if nan_thresh == 0
        keepInd = true(size(XMat,1));
        return
    else
        propNaN = mean(isnan(XMat),2); % proportion of NaNs across rows
        keepInd = (1-propNaN >= nan_thresh);
        if all(~keepInd)
            error('No %s had more than %4.2f%% good values.\nSet a more lenient threshold.',...
                                objectName,nan_thresh*100)
        end
        if all(keepInd)
            fprintf(1,['All %u %s have greater than %4.2f%% good values.' ...
                            ' Keeping them all.\n'], ...
                            length(keepInd),objectName,nan_thresh*100);
        else
            fprintf(1,['Removing %u %s with fewer than %4.2f%% good values:'...
                        ' from %u to %u.\n'],sum(~keepInd),objectName,...
                        nan_thresh*100,length(keepInd),sum(keepInd));
        end
    end
end
%-------------------------------------------------------------------------------

end
