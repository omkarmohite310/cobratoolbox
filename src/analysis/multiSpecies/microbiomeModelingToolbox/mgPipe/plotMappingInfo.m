function Y = plotMappingInfo(resPath, patOrg, reacPat, reacTab, reacNumber, indInfoFilePath, figForm)
% This function computes and automatically plots information coming from
% the mapping data as metabolic diversity and classical multidimensional
% scaling of individuals' reactions repertoire
%
% USAGE:
%
%   Y =plotMappingInfo(resPath, patOrg, reacPat, reacTab, reacNumber, indInfoFilePath, figForm)
%
% INPUTS:
%   resPath:            char with path of directory where results are saved
%   reac:               nx1 cell array with all the unique set of reactions
%                       contained in the models
%   micRea:             binary matrix assessing presence of set of unique
%                       reactions for each of the microbes
%   reacSet:            matrix with names of reactions of each individual
%   reacTab:            binary matrix with presence/absence of reaction per
%                       individual.
%   reacAbun:           matrix with abundance of reaction per individual
%   reacNumber:         number of unique reactions of each individual
%   indInfoFilePath:    char indicating, if stratification criteria are available, 
%                       full path and name to related documentation(default: no)
%                       is available
%   figForm:            format to use for saving figures
%
% OUTPUTS:
%   Y:                  classical multidimensional scaling of individuals'
%                       reactions repertoire
%
% .. Author: - Federico Baldini, 2017-2018

figure(1)
imagesc(reacPat);
colorbar
xlabel('Individuals');  % x-axis label
ylabel('Organisms');  % y-axis label
title('Heatmap individuals | organisms reactions')
print(strcat(resPath, 'Heatmap'), figForm)

if ~exist('indInfoFilePath', 'var')||~exist(indInfoFilePath, 'file')
    patStat = 0;
else
    patStat = 1;
end

if patStat == 0
    % Plot:metabolic diversity
figure(2)
scatter(patOrg, reacNumber, 60, jet(length(patOrg)), 'filled')
xlabel('Microbiota Size')  % x-axis label
ylabel('Number of unique reactions')  % y-axis label
title('Metabolic Diversity')
print(strcat(resPath, 'Metabolic_Diversity'), figForm)

% PCoA -> different reactions per individual
D = pdist(reacTab','jaccard');
[Y, eigvals] = cmdscale(D);
    if (length(Y(1,:))>1)
        figure(3)
        P = [eigvals eigvals / max(abs(eigvals))];
        plot(Y(:, 1), Y(:, 2), 'bx')
        title('PCoA of reaction presence');
        print(strcat(resPath, 'PCoA reactions'), figForm)
    else
        disp('noPcoA will be plotted')     
    end  
% build numbers of patients
% lab = 1:length(Y(:,1)) ;
% lab = strread(num2str(a),'%s');
% labels = lab';
% text(Y(:,1),Y(:,2),labels,'HorizontalAlignment','left');%to insert numbers


else
    % Plot: number of species | number of reactions  disease resolved
    % Patients status: cellarray of same lenght of number of patients 0 means patient with disease 1 means helthy
patTab = readtable(indInfoFilePath);
patients = table2array(patTab(2, :));
patients = patients(1:length(patOrg));
N = length(patients(1, :));
colorMap = [zeros(N, 1), zeros(N, 1), ones(N, 1)];
    for k = 1: length(patients(1, :))
        if str2double(patients(1, k)) == 1
            colorMap(k, :) = [1, 0, 0];  % Red
        end
        if str2double(patients(1, k)) == 0
            colorMap(k, :) = [0, 1, 0];  % Green
        end
    end

figure(2)
scatter(patOrg, reacNumber, 24 * ones(length(reacNumber), 1), colorMap, 'filled');
xlabel('Microbiota Size')  % x-axis label
ylabel('Number of unique reactions')  % y-axis label
title('Metabolic Diversity')
print(strcat(resPath, 'Metabolic_Diversity'), figForm)

% PCoA -> different reactions per individual
D = pdist(reacTab','jaccard');
[Y, eigvals] = cmdscale(D);
figure(3)
P = [eigvals eigvals / max(abs(eigvals))];
    if (length(Y(1,:))>2)
        scatter(Y(:, 1), Y(:, 2), 24 * ones(length(reacNumber), 1), colorMap, 'filled')
        title('PCoA of reaction presence');
        print(strcat(resPath, 'PCoA reactions'), figForm)
    else
        disp('noPcoA will be plotted')    
    end

end

% Plot Eigen number value: diasbled by default
% plot(1:length(eigvals),eigvals,'bo-');
% line([1,length(eigvals)],[0 0],'LineStyle',':','XLimInclude','off',...
%  'Color',[.7 .7 .7])
% axis([1,length(eigvals),min(eigvals),max(eigvals)*1.1]);
% xlabel('Eigenvalue number');
% ylabel('Eigenvalue');
% print(strcat(resPath,'Eigen number value'),figform)

% 3D PCoA plot
% scatter3(Y(:,1),Y(:,2),Y(:,3))
% print(strcat(resPath,'3D PCoA reactions'),figForm)
% text(Y(:,1),Y(:,2),Y(:,3),labels,'HorizontalAlignment','left');%to insert numbers

end
